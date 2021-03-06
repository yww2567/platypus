#' Calculates Jaccard distance between two boxes.
#' @description Calculates Jaccard distance between two boxes.
#' @param box1_w Width of first box.
#' @param box1_h Height of first box.
#' @param box2_w Width of second box.
#' @param box2_h Height of second box.
#' @return Jaccard distance between two boxes.
box_jaccard_distance <- function(box1_w, box1_h, box2_w, box2_h) {
  top <- min(box1_w, box2_w) * min(box1_h, box2_h)
  bottom <- box1_w * box1_h + box2_w * box2_h - top
  1 - top / bottom
}

#' Calculates initial anchor boxes for k-mean++ algorithm.
#' @description Calculates initial anchor boxes for k-mean++ algorithm.
#' @param annot_df `data.frame` with widths and heights of bounding boxes.
#' @param total_anchors Number of anchors to generate.
#' @return Initial anchor boxes for k-mean++ algorithm.
initialize_anchors <- function(annot_df, total_anchors) {
  initial_anchors <- annot_df %>% sample_n(1) %>% select(-label)

  for (anchor in 2:total_anchors) {
    min_distance <- annot_df %>% select(-label) %>%
      pmap_dbl(function(box_w, box_h) {
        current_box <- c(box_w, box_h)
        initial_anchors %>% pmap_dbl(function(box_w, box_h, anchor_id) {
          current_anchor <- c(box_w, box_h)
          box_jaccard_distance(current_box[1], current_box[2],
                               current_anchor[1], current_anchor[2])
        }) %>% min()
      })
    new_anchor_id <- sample(1:nrow(annot_df), 1, prob = min_distance / sum(min_distance))
    initial_anchors <- initial_anchors %>% bind_rows(
      annot_df[new_anchor_id, ] %>% select(-label)
    )
  }
  initial_anchors %>%
    mutate(anchor_id = 1:total_anchors)
}

#' Calculates anchor boxes using k-mean++ algorithm.
#' @description Calculates anchor boxes using k-mean++ algorithm.
#' @importFrom purrr pmap_dbl
#' @importFrom dplyr count group_by summarise ungroup arrange desc sample_n bind_rows
#' @importFrom stats median
#' @param anchors_per_grid Number of anchors per one grid.
#' @param annot_path Annotations directory.
#' @param labels Character vector containing class labels. For example \code{\link[platypus]{coco_labels}}.
#' @param n_iter Maximum number of iteration for k-mean++ algorithm.
#' @param annot_format Annotations format. One of `pascal_voc`, `labelme`.
#' @param seed Random seed.
#' @param centroid_fun Function to use for centroid calculation.
#' @return List of anchor boxes.
#' @export
generate_anchors <- function(anchors_per_grid, annot_path,
                             labels, n_iter = 10, annot_format = "pascal_voc",
                             seed = 1234, centroid_fun = mean) {
  set.seed(seed)
  annot_ext <- if (annot_format == "pascal_voc") ".xml$" else ".json$"
  annot_paths <- list.files(annot_path, pattern = annot_ext, full.names = TRUE)
  total_anchors <- anchors_per_grid * 3
  annotations <- if (annot_format == "pascal_voc") {
    read_annotations_from_xml(annot_paths, NULL, "", labels)
  } else {
    read_annotations_from_labelme(annot_paths, NULL, "", labels)
  }
  annot_df <- annotations %>% map_df(~ {
    image_h <- .x$height
    image_w <- .x$width
    .x$object %>%
      mutate(box_w = (xmax - xmin) / image_w,
             box_h = (ymax - ymin) / image_h
      )
  }) %>% select(box_w, box_h, label)
  print(annot_df %>% count(label))
  initial_anchors <- initialize_anchors(annot_df, total_anchors)
  for(i in 1:n_iter) {
    best_anchors <- annot_df %>% select(-label) %>%
      pmap_dbl(function(box_w, box_h) {
        current_box <- c(box_w, box_h)
        initial_anchors %>% pmap_dbl(function(box_w, box_h, anchor_id) {
          current_anchor <- c(box_w, box_h)
          box_jaccard_distance(current_box[1], current_box[2],
                               current_anchor[1], current_anchor[2])
        }) %>% which.min()
      })
    new_anchors <- annot_df %>% select(-label) %>%
      mutate(anchor_id = best_anchors) %>%
      group_by(anchor_id) %>%
      summarise(box_w = centroid_fun(box_w), box_h = centroid_fun(box_h), .groups = 'drop') %>%
      ungroup() %>%
      arrange(anchor_id)
    if (identical(new_anchors, initial_anchors)) break
    initial_anchors <- new_anchors
  }
  base_plot <- ggplot(annot_df, aes(box_w, box_h, color = label)) + geom_point() + theme_bw()
  plot(base_plot + geom_point(data = new_anchors, color = "red", shape = 23))
  new_anchors_arranged <- new_anchors %>%
    arrange(desc(box_w)) %>% select(-anchor_id)
  1:3 %>% map(~ {
    grid <- .x
    new_anchors_arranged[((grid - 1) * anchors_per_grid + 1):(grid * anchors_per_grid), ] %>%
      pmap(function(box_w, box_h) {
        c(box_w, box_h)
      })
  })
}
